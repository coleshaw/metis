import * as ReactRedux from 'react-redux';
import ListHead from './list-head';

const mapStateToProps = (state, ownProps)=>{
  // state == redux store
  return {
    appState: state.appState
  };
}

const mapDispatchToProps = (dispatch, ownProps)=>{
  return {
    fileSelected: (file)=>{
      let action = { type: 'FILE_SELECTED', file };
      dispatch(action);
    },
    createFolder: (folder_name)=>{
      let action = { type: 'CREATE_FOLDER', folder_name };
      dispatch(action);
    }
  };
}

const ListHeadContainer = ReactRedux.connect(
  mapStateToProps,
  mapDispatchToProps,
)(ListHead);

export default ListHeadContainer;
